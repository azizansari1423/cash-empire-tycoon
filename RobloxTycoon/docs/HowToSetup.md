# How to Set Up in Roblox Studio

## Step 1 — Open Roblox Studio
1. Download Roblox Studio (free) from roblox.com/create
2. Create a **New Baseplate** project

## Step 2 — Set Up the Explorer Structure
In the Explorer panel, create this structure:

```
Workspace
  └── Plots (Folder)
       ├── Plot1 (Model)
       │    ├── Owner (StringValue, Value = "")
       │    ├── Droppers (Folder)
       │    │    └── BasicCoinDropper (Part — position it on your map)
       │    └── Collector (Part — touch = collect items)
       ├── Plot2 (same structure)
       └── Plot3 (same structure)

ServerScriptService
  ├── ModuleScripts (Folder)
  │    ├── DropperConfig (ModuleScript) ← paste DropperConfig.lua
  │    ├── UpgradeConfig (ModuleScript) ← paste UpgradeConfig.lua
  │    └── PlayerDataManager (ModuleScript) ← paste PlayerDataManager.lua
  └── ServerScripts (Folder)
       ├── MainServer (Script) ← paste MainServer.lua
       ├── DropperSystem (ModuleScript) ← paste DropperSystem.lua
       └── ShopHandler (ModuleScript) ← paste ShopHandler.lua

StarterPlayerScripts
  └── CashUI (LocalScript) ← paste CashUI.lua

ReplicatedStorage
  └── UpdateCash (RemoteEvent) ← create manually
```

## Step 3 — Paste the Scripts
- Open each script file from the `src/` folder
- Copy the contents
- Paste into the matching script in Roblox Studio

## Step 4 — Build the Map
- Create a baseplate with 4–8 plot areas marked out
- Each plot is roughly 50x50 studs
- Add a conveyor belt (moving parts) between droppers and collector
- Collector = a part with a Script that fires when touched

## Step 5 — Test in Studio
- Press Play (F5)
- Check Output panel for errors
- Coins should drop and cash should update in the HUD

## Step 6 — Publish
- File → Publish to Roblox
- Set game to Public
- Add a thumbnail and description (see marketing/ folder)

---

## Common Issues
| Problem | Fix |
|---|---|
| Cash not saving | Enable API Services in Game Settings → Security |
| Scripts not found | Make sure folder names match exactly (case-sensitive) |
| Items not dropping | Check BasicCoinDropper part exists in Plot1/Droppers |
