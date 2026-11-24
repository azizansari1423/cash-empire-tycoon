-- MapBuilder v3 — professional tycoon layout
local Workspace    = game:GetService("Workspace")
local Lighting     = game:GetService("Lighting")

-- ── Lighting ──────────────────────────────────────────────────────────────────
Lighting.Ambient        = Color3.fromRGB(100, 110, 130)
Lighting.OutdoorAmbient = Color3.fromRGB(160, 170, 190)
Lighting.Brightness     = 3
Lighting.ClockTime      = 14
Lighting.FogEnd         = 2000
Lighting.FogColor       = Color3.fromRGB(200, 220, 240)
Lighting.EnvironmentDiffuseScale = 0.5
Lighting.EnvironmentSpecularScale = 0.5

-- Sky
local sky = Lighting:FindFirstChildOfClass("Sky") or Instance.new("Sky", Lighting)
sky.SunAngularSize  = 21
sky.MoonAngularSize = 11

-- Bloom (makes neon parts glow realistically)
local bloom = Lighting:FindFirstChildOfClass("BloomEffect") or Instance.new("BloomEffect", Lighting)
bloom.Intensity  = 0.5
bloom.Size       = 24
bloom.Threshold  = 0.95

-- ColorCorrection (warm bright tycoon feel)
local cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect") or Instance.new("ColorCorrectionEffect", Lighting)
cc.Brightness   = 0.06
cc.Contrast     = 0.08
cc.Saturation   = 0.2
cc.TintColor    = Color3.fromRGB(255, 248, 232)

-- Atmosphere
local atm = Lighting:FindFirstChildOfClass("Atmosphere") or Instance.new("Atmosphere", Lighting)
atm.Density    = 0.2
atm.Offset     = 0.1
atm.Color      = Color3.fromRGB(210, 230, 255)
atm.Decay      = Color3.fromRGB(120, 140, 170)
atm.Glare      = 0.15
atm.Haze       = 1.0

-- ── Plot definitions ──────────────────────────────────────────────────────────
local PLOTS = {
	{ name="Plot1", accent=Color3.fromRGB(50,130,255),  bc=BrickColor.new("Bright blue"),   pos=Vector3.new(-90, 0, -90) },
	{ name="Plot2", accent=Color3.fromRGB(255,60,60),   bc=BrickColor.new("Bright red"),    pos=Vector3.new( 90, 0, -90) },
	{ name="Plot3", accent=Color3.fromRGB(50,220,80),   bc=BrickColor.new("Bright green"),  pos=Vector3.new(-90, 0,  90) },
	{ name="Plot4", accent=Color3.fromRGB(255,165,0),   bc=BrickColor.new("Bright orange"), pos=Vector3.new( 90, 0,  90) },
}

local PLOT_W = 60
local PLOT_D = 70
local PLOT_H = 4   -- elevation above ground

-- ── Helper: create a part ─────────────────────────────────────────────────────
local function P(parent, name, size, cframe, brickColor, mat, canCollide)
	local p = Instance.new("Part")
	p.Name       = name
	p.Size       = size
	p.CFrame     = type(cframe) == "vector" and CFrame.new(cframe) or cframe
	p.BrickColor = brickColor or BrickColor.new("Medium stone grey")
	p.Material   = mat or Enum.Material.SmoothPlastic
	p.Anchored   = true
	p.CanCollide = canCollide ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent     = parent
	return p
end

-- SurfaceGui text on a part face
local function label(part, face, text, txtColor, bgColor, bgAlpha)
	local sg  = Instance.new("SurfaceGui")
	sg.Face   = face
	sg.PixelsPerStud = 50
	sg.Parent = part
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1,0,1,0)
	bg.BackgroundColor3 = bgColor or Color3.fromRGB(0,0,0)
	bg.BackgroundTransparency = bgAlpha or 0.4
	bg.BorderSizePixel = 0
	bg.Parent = sg
	Instance.new("UICorner", bg).CornerRadius = UDim.new(0.1, 0)
	local lbl = Instance.new("TextLabel")
	lbl.Size               = UDim2.new(0.9,0,0.9,0)
	lbl.Position           = UDim2.new(0.05,0,0.05,0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3         = txtColor or Color3.fromRGB(255,255,255)
	lbl.TextScaled         = true
	lbl.Font               = Enum.Font.GothamBold
	lbl.Text               = text
	lbl.Parent             = bg
end

-- ── Build a single plot ───────────────────────────────────────────────────────
local function buildPlot(cfg, folder)
	local plot = Instance.new("Model")
	plot.Name  = cfg.name

	local ov = Instance.new("StringValue")
	ov.Name = "Owner"; ov.Value = ""; ov.Parent = plot

	local px, pz   = cfg.pos.X, cfg.pos.Z
	local baseY    = PLOT_H / 2
	local floorY   = PLOT_H
	local accent   = cfg.accent
	local bc       = cfg.bc

	-- ── Base slab (the raised platform) ──────────────────────────────────────
	local slab = P(plot, "Floor",
		Vector3.new(PLOT_W, PLOT_H, PLOT_D),
		CFrame.new(px, baseY, pz),
		BrickColor.new("Light stone grey"), Enum.Material.SmoothPlastic)
	plot.PrimaryPart = slab

	-- Coloured top trim strip (1 stud thick ring)
	P(plot,"TrimF", Vector3.new(PLOT_W+2,0.5,1),   CFrame.new(px,floorY+0.25,pz-PLOT_D/2),   bc)
	P(plot,"TrimB", Vector3.new(PLOT_W+2,0.5,1),   CFrame.new(px,floorY+0.25,pz+PLOT_D/2),   bc)
	P(plot,"TrimL", Vector3.new(1,0.5,PLOT_D),     CFrame.new(px-PLOT_W/2,floorY+0.25,pz),   bc)
	P(plot,"TrimR", Vector3.new(1,0.5,PLOT_D),     CFrame.new(px+PLOT_W/2,floorY+0.25,pz),   bc)

	-- Neon accent strip on front edge
	local neon = P(plot,"NeonFront", Vector3.new(PLOT_W+2,0.3,0.4),
		CFrame.new(px,floorY+0.65,pz-PLOT_D/2),
		BrickColor.new("White"), Enum.Material.Neon, false)
	neon.Color = accent; neon.CanCollide = false

	-- ── Back factory wall ─────────────────────────────────────────────────────
	local wallH = 14
	local backWall = P(plot,"BackWall",
		Vector3.new(PLOT_W,wallH,1.5),
		CFrame.new(px, floorY+wallH/2, pz-PLOT_D/2+0.75),
		bc, Enum.Material.SmoothPlastic)
	label(backWall, Enum.NormalId.Front,
		cfg.name .. "\nAVAILABLE",
		Color3.fromRGB(255,255,255), Color3.fromRGB(0,0,0), 0.5)

	-- Neon top strip on back wall
	local topNeon = P(plot,"WallNeon", Vector3.new(PLOT_W,0.5,0.4),
		CFrame.new(px,floorY+wallH+0.25,pz-PLOT_D/2+0.75),
		BrickColor.new("White"), Enum.Material.Neon, false)
	topNeon.Color = accent; topNeon.CanCollide = false

	-- Side walls (half height, open front)
	P(plot,"SideWallL", Vector3.new(1.5,8,PLOT_D*0.6),
		CFrame.new(px-PLOT_W/2+0.75,floorY+4,pz-PLOT_D*0.2),
		bc, Enum.Material.SmoothPlastic)
	P(plot,"SideWallR", Vector3.new(1.5,8,PLOT_D*0.6),
		CFrame.new(px+PLOT_W/2-0.75,floorY+4,pz-PLOT_D*0.2),
		bc, Enum.Material.SmoothPlastic)

	-- Roof overhang above dropper area
	P(plot,"Roof", Vector3.new(PLOT_W,0.8,PLOT_D*0.55),
		CFrame.new(px,floorY+wallH-0.4,pz-PLOT_D*0.22),
		BrickColor.new("Dark stone grey"), Enum.Material.SmoothPlastic)

	-- ── Dropper platform ──────────────────────────────────────────────────────
	local dpY = floorY + 0.5
	P(plot,"DropperPlatform",
		Vector3.new(PLOT_W-8,1,22),
		CFrame.new(px,dpY,pz-18),
		BrickColor.new("Dark stone grey"), Enum.Material.SmoothPlastic)

	-- Machine-style dropper stand (taller, with detail layers)
	local droppers = Instance.new("Folder"); droppers.Name="Droppers"; droppers.Parent=plot

	-- Main stand body
	local stand = P(droppers,"BasicCoinDropper",
		Vector3.new(6,5,6),
		CFrame.new(px-12,floorY+2.5,pz-22),
		BrickColor.new("Dark stone grey"), Enum.Material.Metal)
	-- Gold top cap
	local cap = P(droppers,"BasicCoinCap",
		Vector3.new(6,1,6),
		CFrame.new(px-12,floorY+5.5,pz-22),
		BrickColor.new("Bright yellow"), Enum.Material.SmoothPlastic)
	-- Label on stand front
	label(stand, Enum.NormalId.Front,
		"COIN\nDROPPER",
		Color3.fromRGB(255,215,0), Color3.fromRGB(0,0,0), 0.3)

	-- Conveyor lane (textured stripes)
	for i = 0, 5 do
		local stripe = P(plot,"Lane_"..i,
			Vector3.new(PLOT_W-8,0.2,2),
			CFrame.new(px,dpY+0.6,pz-10+i*3.2),
			i%2==0 and BrickColor.new("Dark stone grey") or BrickColor.new("Medium stone grey"),
			Enum.Material.SmoothPlastic, false)
		stripe.CanCollide = false
	end

	-- ── Collector zone (front of plot) ────────────────────────────────────────
	local collectY = floorY
	-- Glowing pad
	local pad = P(plot,"Collector",
		Vector3.new(PLOT_W-8,0.4,12),
		CFrame.new(px,collectY+0.2,pz+24),
		BrickColor.new("Bright green"), Enum.Material.Neon, false)
	pad.CanCollide = false; pad.Color = Color3.fromRGB(0,255,80)

	-- Arch/frame around collector
	P(plot,"CollArch1", Vector3.new(1.5,8,1.5),
		CFrame.new(px-PLOT_W/2+5,floorY+4,pz+18), bc)
	P(plot,"CollArch2", Vector3.new(1.5,8,1.5),
		CFrame.new(px+PLOT_W/2-5,floorY+4,pz+18), bc)
	local archTop = P(plot,"CollArchTop", Vector3.new(PLOT_W-8,1.5,1.5),
		CFrame.new(px,floorY+8.75,pz+18), bc)
	label(archTop, Enum.NormalId.Front,
		"COLLECT HERE",
		Color3.fromRGB(0,255,80), Color3.fromRGB(0,0,0), 0.4)

	-- Entry ramp
	P(plot,"Ramp",
		Vector3.new(8,PLOT_H,2),
		CFrame.new(px,PLOT_H/2,pz+PLOT_D/2-1) * CFrame.Angles(math.rad(-25),0,0),
		BrickColor.new("Light stone grey"), Enum.Material.SmoothPlastic)

	plot.Parent = folder
end

-- ── Build the world ───────────────────────────────────────────────────────────
local old = Workspace:FindFirstChild("Plots")
if old then old:Destroy() end
local old2 = Workspace:FindFirstChild("Hub")
if old2 then old2:Destroy() end

local plotsFolder = Instance.new("Folder")
plotsFolder.Name   = "Plots"
plotsFolder.Parent = Workspace

-- Baseplate
local bp = Workspace:FindFirstChild("Baseplate")
if bp then
	bp.BrickColor = BrickColor.new("Earth green")
	bp.Material   = Enum.Material.Grass
	bp.Size        = Vector3.new(600,20,600)
	bp.CFrame      = CFrame.new(0,-10,0)
end

-- ── Central Hub ───────────────────────────────────────────────────────────────
local hub = Instance.new("Model"); hub.Name="Hub"; hub.Parent=Workspace

-- Elevated hub platform
P(hub,"HubBase",    Vector3.new(50,4,50), CFrame.new(0,2,0),
	BrickColor.new("Pearl"), Enum.Material.SmoothPlastic)
P(hub,"HubTop",     Vector3.new(50,0.5,50), CFrame.new(0,4.25,0),
	BrickColor.new("White"), Enum.Material.SmoothPlastic)

-- Neon ring on hub
for i,c in ipairs({
	{Vector3.new(52,0.4,2), CFrame.new(0,4.6,25)},
	{Vector3.new(52,0.4,2), CFrame.new(0,4.6,-25)},
	{Vector3.new(2,0.4,50), CFrame.new(25,4.6,0)},
	{Vector3.new(2,0.4,50), CFrame.new(-25,4.6,0)},
}) do
	local n = P(hub,"HubNeon"..i, c[1], c[2], BrickColor.new("White"), Enum.Material.Neon, false)
	n.Color = Color3.fromRGB(255,215,0); n.CanCollide=false
end

-- Title sign arch
local arch = P(hub,"TitleArch",
	Vector3.new(36,8,2), CFrame.new(0,8,-23),
	BrickColor.new("Bright yellow"), Enum.Material.SmoothPlastic)
label(arch, Enum.NormalId.Front, "CASH EMPIRE TYCOON",
	Color3.fromRGB(0,0,0), Color3.fromRGB(255,215,0), 0)

-- Arch pillars
P(hub,"ArchPillarL", Vector3.new(2.5,12,2.5), CFrame.new(-19,6,-23), BrickColor.new("Bright yellow"))
P(hub,"ArchPillarR", Vector3.new(2.5,12,2.5), CFrame.new( 19,6,-23), BrickColor.new("Bright yellow"))

-- Paths from hub to plots
local paths = {
	{Vector3.new(-55,0.3,0),  Vector3.new(20,0.6,10)},
	{Vector3.new( 55,0.3,0),  Vector3.new(20,0.6,10)},
	{Vector3.new(0,0.3,-55),  Vector3.new(10,0.6,20)},
	{Vector3.new(0,0.3, 55),  Vector3.new(10,0.6,20)},
}
for i,d in ipairs(paths) do
	P(hub,"Path"..i, d[2], CFrame.new(d[1]),
		BrickColor.new("Light stone grey"), Enum.Material.SmoothPlastic)
end

-- Build all 4 plots
for _, cfg in ipairs(PLOTS) do
	buildPlot(cfg, plotsFolder)
end

-- SpawnLocation
local sp = Workspace:FindFirstChild("SpawnLocation")
if sp then
	sp.CFrame = CFrame.new(0,5.5,0)
	sp.BrickColor = BrickColor.new("Bright yellow")
	sp.Size = Vector3.new(6,1,6)
else
	local s = Instance.new("SpawnLocation")
	s.CFrame = CFrame.new(0,5.5,0); s.BrickColor=BrickColor.new("Bright yellow")
	s.Size=Vector3.new(6,1,6); s.Anchored=true; s.Parent=Workspace
end

print("[MapBuilder] World ready.")
