-- 30-step upgrade progression (from GDD)
-- income = cash per second added when this upgrade is owned
-- multiplier = multiplies ALL income accumulated so far
-- isRebirth = triggers prestige on purchase

local UpgradeTable = {
	-- ── Tier 1: Starter Street ──────────────────────────────────────────────────
	{ id=1,  name="Starter ATM",           cost=0,          income=5,       tier=1, color=BrickColor.new("Bright yellow")    },
	{ id=2,  name="Cash Collector Pad",    cost=25,         income=0,       tier=1, color=BrickColor.new("Bright green")     },
	{ id=3,  name="Cash Tree",             cost=75,         income=10,      tier=1, color=BrickColor.new("Bright green")     },
	{ id=4,  name="ATM Upgrade Lv.2",      cost=200,        income=20,      tier=1, color=BrickColor.new("Bright yellow")    },
	{ id=5,  name="Plot Fence & Sidewalk", cost=350,        income=0,       tier=1, color=BrickColor.new("Sand yellow")      },

	-- ── Tier 2: Cash Factory ─────────────────────────────────────────────────────
	{ id=6,  name="Conveyor Belt",         cost=600,        income=0,       tier=2, color=BrickColor.new("Dark stone grey")  },
	{ id=7,  name="Cash Printer #1",       cost=1000,       income=45,      tier=2, color=BrickColor.new("Bright orange")   },
	{ id=8,  name="Bill Multiplier 1.5x",  cost=2200,       income=0,       tier=2, multiplier=1.5, color=BrickColor.new("Lime green") },
	{ id=9,  name="Cash Printer #2",       cost=4000,       income=90,      tier=2, color=BrickColor.new("Bright orange")   },
	{ id=10, name="Vault Collector",       cost=7500,       income=150,     tier=2, color=BrickColor.new("Dark grey")        },
	{ id=11, name="Gold Bar Dropper",      cost=14000,      income=280,     tier=2, color=BrickColor.new("Bright yellow")   },
	{ id=12, name="Laser Upgrader 2x",     cost=25000,      income=0,       tier=2, multiplier=2.0, color=BrickColor.new("Cyan")      },
	{ id=13, name="Diamond Dropper",       cost=45000,      income=600,     tier=2, color=BrickColor.new("Teal")             },
	{ id=14, name="Factory Walls & Roof",  cost=60000,      income=0,       tier=2, color=BrickColor.new("Sand grey")        },

	-- ── Tier 3: Bank Empire HQ ──────────────────────────────────────────────────
	{ id=15, name="Bank HQ Foundation",    cost=100000,     income=1000,    tier=3, color=BrickColor.new("Sand blue")        },
	{ id=16, name="Builder NPC",           cost=160000,     income=1500,    tier=3, color=BrickColor.new("Nougat")           },
	{ id=17, name="ATM Wall (Golden 3x)",  cost=250000,     income=2500,    tier=3, color=BrickColor.new("Bright yellow")   },
	{ id=18, name="Trading Floor",         cost=420000,     income=4000,    tier=3, color=BrickColor.new("Sand blue")        },
	{ id=19, name="Manager NPC",           cost=650000,     income=6500,    tier=3, color=BrickColor.new("Nougat")           },
	{ id=20, name="Gold Vault Floor",      cost=1100000,    income=11000,   tier=3, color=BrickColor.new("Bright yellow")   },
	{ id=21, name="HQ Roof & Neon Sign",   cost=1800000,    income=18000,   tier=3, color=BrickColor.new("Bright blue")     },

	-- ── Tier 4: Billionaire Flex ────────────────────────────────────────────────
	{ id=22, name="Waterfront Dock",       cost=2500000,    income=0,       tier=4, color=BrickColor.new("Sand green")       },
	{ id=23, name="Luxury Mansion",        cost=4000000,    income=35000,   tier=4, color=BrickColor.new("White")            },
	{ id=24, name="Sports Car Spawner",    cost=6000000,    income=0,       tier=4, color=BrickColor.new("Bright red")       },
	{ id=25, name="Speedboat",             cost=9000000,    income=0,       tier=4, color=BrickColor.new("Bright blue")     },
	{ id=26, name="Mega Yacht",            cost=15000000,   income=85000,   tier=4, color=BrickColor.new("White")            },
	{ id=27, name="Rooftop Helipad",       cost=22000000,   income=0,       tier=4, color=BrickColor.new("Dark stone grey") },
	{ id=28, name="Golden Helicopter",     cost=35000000,   income=150000,  tier=4, color=BrickColor.new("Bright yellow")   },
	{ id=29, name="Golden Crown Statue",   cost=60000000,   income=300000,  tier=4, color=BrickColor.new("Bright yellow")   },

	-- ── Tier 5: Endgame ─────────────────────────────────────────────────────────
	{ id=30, name="REBIRTH PORTAL",        cost=100000000,  income=0,       tier=5, isRebirth=true, color=BrickColor.new("Hot pink") },
}

return UpgradeTable
