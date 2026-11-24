# Cash Empire Tycoon — Game Design Document (GDD)

## 1. Game Overview
* **Title:** Cash Empire Tycoon
* **Genre:** Modern Tycoon / Simulator Hybrid
* **Target Audience:** Ages 8–16 across Mobile, Tablet, and PC *(design UI for mobile thumbs first, as ~70%+ of Roblox traffic is mobile)*.
* **Core Fantasy:** Start from a single sidewalk ATM and build your way up to a massive Cash Factory, a golden Bank Empire HQ, a waterfront mansion, mega yachts, and a private golden helicopter.
* **Server Size:** 6 players per server (6 identical tycoon plots arranged around a central City Plaza / Harbor so players can see and visit each other's empires).

---

## 2. Map Layout
* **6 Tycoon Plots:** Each plot is divided into four visual zones:
  1. **Street Front** (Starter area)
  2. **Factory Floor** (Middle industrial conveyor zone)
  3. **Skyscraper Pad** (Back foundation for Bank Empire HQ)
  4. **Waterfront Dock** (Side/back harbor edge for the mansion, speedboat, and yacht)
* **Central City Plaza:** A neutral safe zone in the center of the map featuring:
  * **Global Leaderboards:** *Most Cash*, *Most Rebirths*, and *Top Donors*.
  * **Group Reward Chest:** Rewards players who join your Roblox Group.
  * **Cash Drop Zone:** Spawns free glowing cash crates every 3 minutes to encourage players to leave their plots and interact.

---

## 3. Core Gameplay Loop
1. **Claim Plot:** Player spawns in the plaza, follows a glowing green beam to an open plot, and steps on the free **$0 Claim Pad**.
2. **Generate Cash:** The free Starter ATM immediately begins spitting out cash bills with crisp sound effects and floating `+$5` popups.
3. **Collect & Upgrade:** Player steps on the green **Cash Collector Pad** to bank cash, then steps on glowing **Purchase Buttons** to unlock droppers, upgraders, and buildings.
4. **Active Boosts (Zero Dead Time):** Between larger upgrades, players can click their ATM for instant bonus cash, collect plaza cash drops, or claim Playtime Rewards.
5. **Expand & Flex:** Unlock the multi-floor Bank HQ, hire animated NPC workers, and buy luxury vehicles (sports cars, yacht, flyable helicopter) to flex across the server.
6. **Rebirth:** Complete the Bank HQ to Rebirth—resetting the plot in exchange for a permanent **+100% Cash Multiplier** (`2x`, `3x`, `4x`...) and exclusive Rebirth-only items.

---

## 4. Complete 30-Upgrade Progression Table
Balanced so the first 5 minutes feel fast and rewarding, with a full first run taking **~30–40 minutes** (optimal for Roblox engagement and session-length metrics).

| # | Tier | Upgrade Name | Cost | Income / Sec | Notes |
|---|---|---|---|---|---|
| 1 | **1. Starter Street** | Claim Plot + Starter ATM | $0 | $5/s | Instant dopamine; clickable for +$5/click |
| 2 | | Cash Collector Pad | $25 | — | Collects bills from conveyor |
| 3 | | Cash Tree #1 | $75 | +$10/s | Drops green bills around tree |
| 4 | | ATM Upgrade (Lv. 2) | $200 | +$20/s | Faster bill spitting |
| 5 | | Plot Fence & Sidewalk | $350 | — | Visual polish + unlocks Factory Floor |
| 6 | **2. Cash Factory** | Conveyor Belt #1 | $600 | — | Connects factory droppers to vault |
| 7 | | Cash Printer #1 | $1,000 | +$45/s | Drops bundled cash stacks |
| 8 | | Bill Multiplier Gate (1.5x) | $2,200 | x1.5 | Bills glow green as they pass through |
| 9 | | Cash Printer #2 | $4,000 | +$90/s | Second printer on belt |
| 10 | | Vault Collector | $7,500 | +$150/s | Armored vault at end of belt |
| 11 | | Gold Bar Dropper | $14,000 | +$280/s | Spawns shiny gold bars |
| 12 | | Laser Upgrader (2x) | $25,000 | x2.0 | Doubles value of passing cash/gold |
| 13 | | Diamond Dropper | $45,000 | +$600/s | Spawns glowing blue diamonds |
| 14 | | Factory Walls & Roof | $60,000 | — | Visual milestone |
| 15 | **3. Bank Empire HQ** | Bank HQ Foundation & Lobby | $100,000 | +$1,000/s | Ground floor of skyscraper |
| 16 | | Hire Builder NPC #1 | $160,000 | +$1,500/s | Animated NPC working on HQ |
| 17 | | ATM Wall (3x Golden ATMs) | $250,000 | +$2,500/s | High-speed lobby ATMs |
| 18 | | Bank HQ Floor 2 (Trading Floor) | $420,000 | +$4,000/s | Glass skyscraper level |
| 19 | | Hire Manager NPC | $650,000 | +$6,500/s | Boosts all factory droppers by 25% |
| 20 | | Bank HQ Floor 3 (Gold Vault) | $1.1M | +$11,000/s | Massive gold stack display |
| 21 | | Bank HQ Roof & Neon Sign | $1.8M | +$18,000/s | Adds glowing **"BANK HQ"** sign |
| 22 | **4. Billionaire Flex** | Waterfront Dock | $2.5M | — | Unlocks harbor area |
| 23 | | Luxury Mansion | $4.0M | +$35,000/s | Golden waterfront villa |
| 24 | | Sports Car Spawner | $6.0M | — | Driveable yellow & orange supercars |
| 25 | | Speedboat | $9.0M | — | Driveable on water |
| 26 | | Mega Yacht | $15.0M | +$85,000/s | Walkable + driveable yacht |
| 27 | | Rooftop Helipad | $22.0M | — | Placed on top of Bank HQ |
| 28 | | Golden Helicopter | $35.0M | +$150,000/s | Flyable across the whole map |
| 29 | | Golden Crown Statue | $60.0M | +$300,000/s | Giant flexing monument |
| 30 | **5. Endgame** | **REBIRTH PORTAL** | $100.0M | **+1x Mult** | Resets base, keeps Gamepasses & Rebirths |

---

## 5. UI / UX & Game Feel ("Juice")
* **Clean HUD Layout:**
  * **Top Center:** Current Cash (`$12.4K`), Cash/Sec (`+$450/s`), and a progress bar toward the next Rebirth.
  * **Left Side:** 4 compact square buttons — **Shop**, **Rewards** *(with red notification badge)*, **Rebirth**, and **Settings** *(Music/SFX toggles)*.
  * **Bottom Center:** Auto-Collect indicator & active Boost timers (e.g., `2x Cash: 14:32`).
* **Onboarding Guidance:** A glowing neon arrow beam on the ground pointing directly to the **cheapest affordable button** so new players never get lost.
* **Audio & Visual Feedback:**
  * Crisp *"cha-ching"* sound on cash collection (pitch-shifted slightly higher on rapid clicks).
  * Floating green `+$250` text popups when collecting cash.
  * Buildings and droppers **pop in with a smooth `TweenService` bounce animation** rather than snapping into place instantly.

---

## 6. Monetization Blueprint
Priced to be accessible for players with standard 400–800 Robux gift cards while focusing on convenience and speed rather than pay-to-win walls.

| Type | Item Name | Price (Robux) | Benefit |
|---|---|---|---|
| **Gamepass** | **2x Cash Forever** | 249 | Permanently doubles all cash earned (typically #1 seller) |
| **Gamepass** | **Auto-Collect** | 149 | Deposits cash straight to wallet every 2 seconds |
| **Gamepass** | **VIP Empire Pass** | 399 | Gold chat tag, +25% cash, exclusive Golden Dropper |
| **Gamepass** | **2x Walkspeed / Jetpack** | 99 | Fast movement across plot and city |
| **Dev Product** | **Starter Pack (5-min Popup)** | 49 | Instant $5,000 + 15 mins of 2x Cash (high conversion) |
| **Dev Product** | **Server 2x Cash (15m)** | 79 | Announces buyer's name to server + 2x cash for everyone |
| **Dev Product** | **Cash Packs (S / M / L)** | 49 / 149 / 399 | Dynamic payout: `10x / 35x / 120x` player's current Cash/Sec |

---

## 7. Retention & Growth Features
* **Playtime Rewards:** 6 free gifts unlocked at **2m, 5m, 10m, 20m, 35m, and 60m** (cash bursts, temporary 2x boosts, and cosmetics).
* **Daily Login Streak:** Day 1 through Day 7 escalating cash multipliers, culminating in an exclusive Day 7 Golden Car.
* **Promo Codes:** Built-in code redemption UI (e.g., `RELEASE`, `CASH100`) to reward likes, favorites, and social media followers.
* **Group Perk:** Joining your Roblox Group unlocks an in-game chest granting a **+15% permanent cash boost**, building a reusable audience for updates and future games.

---

## 8. Technical Architecture (Roblox Studio / Luau)
* **Data Persistence:** Use **ProfileStore** (successor to ProfileService) to reliably save `Cash`, `Rebirths`, `UnlockedButtons` (array of button IDs), `Playtime`, and `DailyStreak` with session-locking to prevent data loss and duplication.
* **Server-Authoritative Security (Anti-Exploit):**
  * **Server:** Handles all cash calculations, button purchase validation, Gamepass checks, and upgrade unlocks.
  * **Client:** Handles UI animations, audio feedback, button hover effects, and rendering physical moving cash bills on conveyors (keeping server CPU/physics lag near zero even with 6 maxed-out plots).
* **Recommended Explorer Structure:**
  * `ReplicatedStorage/Modules` → `UpgradeConfig` (30-upgrade table), `FormatNumber` (`1.5K`, `2.3M`).
  * `ServerScriptService/TycoonManager` → Plot claiming, button touch detection, income tick loop, ProfileStore integration.
  * `StarterGui/MainHUD` → Responsive UI built with `Scale` + `UIAspectRatioConstraint` (never `Offset`).

---

## 9. Side-Hustle Execution Roadmap
1. **Phase 1 — Lean MVP (Weeks 1–3):**
   * Build 1 complete plot (duplicate 6x around the central plaza).
   * Implement the 30 upgrades, ProfileStore auto-save, 4 Gamepasses, Playtime Rewards, and 1 Rebirth loop.
2. **Phase 2 — Soft Launch & Analytics (Week 4):**
   * Publish and monitor the **Analytics** tab in the Roblox Creator Dashboard.
   * Target benchmarks: **10+ min** average playtime and **10%+** Day 1 retention.
3. **Phase 3 — Weekly Updates & Short-Form Marketing (Ongoing):**
   * Ship weekly mini-updates (e.g., *"NEW Bank Heist Event!"*, *"NEW Private Jet!"*).
   * Post 15-second time-lapse videos (`$0 to $1 Billion`) on YouTube Shorts, TikTok, and Instagram Reels to drive free organic traffic.