-- VehicleSystem — spawns driveable Sports Car (#24), Speedboat (#25), Mega Yacht (#26) & Golden Helicopter (#28)
local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")

local VEHICLE_CONFIGS = {
	[24] = {
		name   = "SportsCar",
		label  = "SPORTS CAR",
		offset = Vector3.new(-38, 2.5, 10),
		color  = Color3.fromRGB(220, 35, 45),
		accent = Color3.fromRGB(25, 25, 30),
		mode   = "car",
		speed  = 95,
		turn   = 2.6,
	},
	[25] = {
		name   = "Speedboat",
		label  = "SPEEDBOAT",
		offset = Vector3.new(38, 2.0, 12),
		color  = Color3.fromRGB(30, 130, 245),
		accent = Color3.fromRGB(245, 245, 250),
		mode   = "boat",
		speed  = 85,
		turn   = 2.4,
	},
	[26] = {
		name   = "MegaYacht",
		label  = "MEGA YACHT",
		offset = Vector3.new(44, 3.0, -14),
		color  = Color3.fromRGB(245, 245, 250),
		accent = Color3.fromRGB(255, 200, 40),
		mode   = "boat",
		speed  = 65,
		turn   = 1.6,
	},
	[28] = {
		name   = "GoldenHelicopter",
		label  = "GOLDEN HELICOPTER",
		offset = Vector3.new(-42, 3.5, -14),
		color  = Color3.fromRGB(255, 200, 35),
		accent = Color3.fromRGB(30, 30, 35),
		mode   = "heli",
		speed  = 80,
		turn   = 2.5,
	},
}

local function weldParts(root, part)
	local w = Instance.new("WeldConstraint")
	w.Part0 = root; w.Part1 = part; w.Parent = root
end

local function makePart(parent, size, cframe, color, mat, transparency)
	local p = Instance.new("Part")
	p.Size = size; p.CFrame = cframe; p.Color = color
	p.Material      = mat or Enum.Material.SmoothPlastic
	p.Transparency  = transparency or 0
	p.TopSurface    = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide    = true
	p.Anchored      = false
	p.Parent        = parent
	return p
end

local function buildVehicle(cfg, spawnCF)
	local model = Instance.new("Model")
	model.Name = "Vehicle_" .. cfg.name

	local seat = Instance.new("VehicleSeat")
	seat.Name           = "DriverSeat"
	seat.Size           = Vector3.new(2.4, 0.6, 2.4)
	seat.CFrame         = spawnCF
	seat.Color          = cfg.accent
	seat.Material       = Enum.Material.SmoothPlastic
	seat.MaxSpeed       = cfg.speed
	seat.TurnSpeed      = cfg.turn
	seat.Torque         = 25
	seat.HeadsUpDisplay = false
	seat.Parent         = model
	model.PrimaryPart   = seat

	if cfg.mode == "car" then
		local chassis = makePart(model, Vector3.new(6.5,1.3,13),  spawnCF * CFrame.new(0,-0.3,0),    cfg.color, Enum.Material.Metal)
		local hood    = makePart(model, Vector3.new(6.1,0.7,4.2), spawnCF * CFrame.new(0,0.5,-4.1),  cfg.color, Enum.Material.Metal)
		local glass   = makePart(model, Vector3.new(5.6,1.4,3.2), spawnCF * CFrame.new(0,1.0,-1.2),  Color3.fromRGB(40,60,85), Enum.Material.Glass, 0.45)
		local spoiler = makePart(model, Vector3.new(6.4,0.3,1.1), spawnCF * CFrame.new(0,1.2,5.8),   cfg.accent)
		weldParts(seat,chassis); weldParts(seat,hood); weldParts(seat,glass); weldParts(seat,spoiler)

		for _, off in ipairs({
			Vector3.new(-3.4,-0.8,-4.2), Vector3.new(3.4,-0.8,-4.2),
			Vector3.new(-3.4,-0.8, 4.2), Vector3.new(3.4,-0.8, 4.2),
		}) do
			local w = makePart(model, Vector3.new(1.0,2.2,2.2), spawnCF * CFrame.new(off), cfg.accent)
			w.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.05, 0, 100, 1)
			weldParts(seat, w)
		end

	elseif cfg.mode == "boat" then
		local isYacht = cfg.name == "MegaYacht"
		local w = isYacht and 12 or 6.5
		local l = isYacht and 26 or 14
		local hull = makePart(model, Vector3.new(w,2.0,l),     spawnCF * CFrame.new(0,-0.7,0), cfg.color)
		local trim = makePart(model, Vector3.new(w+0.4,0.4,l+0.4), spawnCF * CFrame.new(0,0.2,0), cfg.accent, Enum.Material.Neon)
		trim.CanCollide = false
		weldParts(seat,hull); weldParts(seat,trim)

		if isYacht then
			local cabin = makePart(model, Vector3.new(9,4.2,12),  spawnCF * CFrame.new(0,2.3,1.5),  Color3.fromRGB(250,250,255))
			local deck  = makePart(model, Vector3.new(9.4,0.4,12.4), spawnCF * CFrame.new(0,4.5,1.5), cfg.accent)
			weldParts(seat,cabin); weldParts(seat,deck)
		else
			local windshield = makePart(model, Vector3.new(5.8,1.3,0.4), spawnCF * CFrame.new(0,0.9,-2.5), Color3.fromRGB(50,180,255), Enum.Material.Glass, 0.4)
			weldParts(seat, windshield)
		end

	elseif cfg.mode == "heli" then
		local cabin = makePart(model, Vector3.new(6.2,4.2,9.5), spawnCF * CFrame.new(0,1.2,0),    cfg.color, Enum.Material.Metal)
		local glass = makePart(model, Vector3.new(5.8,2.6,2.5), spawnCF * CFrame.new(0,1.4,-4.2), Color3.fromRGB(40,50,70), Enum.Material.Glass, 0.4)
		local tail  = makePart(model, Vector3.new(1.4,1.4,10),  spawnCF * CFrame.new(0,1.6,9.2),  cfg.color, Enum.Material.Metal)
		local skidL = makePart(model, Vector3.new(0.5,0.5,10),  spawnCF * CFrame.new(-2.6,-1.6,0), cfg.accent)
		local skidR = makePart(model, Vector3.new(0.5,0.5,10),  spawnCF * CFrame.new( 2.6,-1.6,0), cfg.accent)
		local rotor = makePart(model, Vector3.new(18,0.25,1.2), spawnCF * CFrame.new(0,3.8,0),    cfg.accent)
		rotor.CanCollide = false
		weldParts(seat,cabin); weldParts(seat,glass); weldParts(seat,tail)
		weldParts(seat,skidL); weldParts(seat,skidR); weldParts(seat,rotor)

		task.spawn(function()
			while model.Parent do
				if seat.Occupant then
					rotor.CFrame = rotor.CFrame * CFrame.Angles(0, math.rad(28), 0)
				end
				task.wait(0.03)
			end
		end)
	end

	local attachment = Instance.new("Attachment", seat)

	local linearVel = Instance.new("LinearVelocity")
	linearVel.Attachment0 = attachment
	linearVel.MaxForce    = 1e6
	linearVel.RelativeTo  = Enum.ActuatorRelativeTo.World
	linearVel.Enabled     = false
	linearVel.Parent      = seat

	local alignOri = Instance.new("AlignOrientation")
	alignOri.Attachment0    = attachment
	alignOri.Mode           = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.MaxTorque      = 1e6
	alignOri.Responsiveness = 18
	alignOri.Enabled        = false
	alignOri.Parent         = seat

	task.spawn(function()
		local currentYaw = select(2, seat.CFrame:ToEulerAnglesYXZ())
		while model.Parent do
			local occupant = seat.Occupant
			if occupant then
				local driverPlr = Players:GetPlayerFromCharacter(occupant.Parent)
				if driverPlr then
					pcall(function() seat:SetNetworkOwner(driverPlr) end)
				end

				linearVel.Enabled = true
				alignOri.Enabled  = true

				local throttle = seat.ThrottleFloat
				local steer    = seat.SteerFloat

				currentYaw -= steer * math.rad(cfg.turn * 1.4)
				alignOri.CFrame = CFrame.Angles(0, currentYaw, 0)

				local forward = CFrame.Angles(0, currentYaw, 0).LookVector
				local vertVel = 0

				if cfg.mode == "heli" then
					if occupant.Jump then
						vertVel = 36
					elseif seat.Position.Y > 8 and throttle == 0 then
						vertVel = 0
					elseif seat.Position.Y > 6 then
						vertVel = -14
					end
				else
					vertVel = seat.AssemblyLinearVelocity.Y
				end

				linearVel.VectorVelocity = (forward * (throttle * cfg.speed)) + Vector3.new(0, vertVel, 0)
			else
				linearVel.Enabled = false
				alignOri.Enabled  = false
				currentYaw = select(2, seat.CFrame:ToEulerAnglesYXZ())
			end
			task.wait(0.03)
		end
	end)

	return model
end

local function spawnVehiclePad(plot, upgradeId)
	local cfg = VEHICLE_CONFIGS[upgradeId]
	if not cfg then return end
	local pp = plot.PrimaryPart
	if not pp then return end

	local padName = "VehiclePad_" .. upgradeId
	if plot:FindFirstChild(padName) then return end

	local basePos = pp.Position + cfg.offset

	local pad = Instance.new("Part")
	pad.Name       = padName
	pad.Size       = Vector3.new(10, 0.5, 10)
	pad.CFrame     = CFrame.new(basePos.X, 0.3, basePos.Z)
	pad.Color      = cfg.color
	pad.Material   = Enum.Material.Neon
	pad.Anchored   = true
	pad.CanCollide = false
	pad.Parent     = plot

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText              = "Respawn " .. cfg.label
	prompt.ObjectText              = "Owner Vehicle"
	prompt.HoldDuration            = 0.3
	prompt.MaxActivationDistance   = 14
	prompt.Parent                  = pad

	local function respawn()
		local old = plot:FindFirstChild("Vehicle_" .. cfg.name)
		if old then old:Destroy() end
		local v = buildVehicle(cfg, CFrame.new(basePos + Vector3.new(0, 2.5, 0)))
		v.Parent = plot
	end

	prompt.Triggered:Connect(function(plr)
		local ov = plot:FindFirstChild("Owner")
		if ov and ov.Value == plr.Name then respawn() end
	end)

	respawn()
end

local function watchPlot(plot)
	for id in pairs(VEHICLE_CONFIGS) do
		if plot:FindFirstChild("Upgrade_" .. id) then
			spawnVehiclePad(plot, id)
		end
	end

	plot.ChildAdded:Connect(function(child)
		local idStr = child.Name:match("^Upgrade_(%d+)$")
		local id    = idStr and tonumber(idStr)
		if id and VEHICLE_CONFIGS[id] then
			spawnVehiclePad(plot, id)
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

print("[VehicleSystem] Sports Car, Speedboat, Mega Yacht & Golden Helicopter ready.")
